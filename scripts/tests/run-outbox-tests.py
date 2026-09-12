#!/usr/bin/env python3
"""Compile production AppStore state logic with an in-memory transport; no services or UI.

The temporary AppStore copy only removes its UIKit import and redirects the journal.
DTOs, Models, PendingSubmission and ReferenceData are copied from production. The real
BridgeClient, Keychain, pasteboard and haptic implementations are never linked.
"""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--suite", choices=("outbox", "session-pagination", "unread", "metadata-actions", "computer-switch", "stream-lifecycle", "fork", "file-listing", "hook-review"), default="outbox")
parser.add_argument("--app-store-ref", help="For metadata-actions or stream-lifecycle: compile AppStore from a local Git revision without checking it out")
args = parser.parse_args()
suite = args.suite
if args.app_store_ref and suite not in ("metadata-actions", "stream-lifecycle"):
    parser.error("--app-store-ref is limited to metadata-actions and stream-lifecycle")
uses_shared_fixtures = suite != "outbox"
artifact_prefix = {"outbox": "OUTBOX", "session-pagination": "SESSION_PAGINATION", "unread": "UNREAD", "metadata-actions": "METADATA_ACTION", "computer-switch": "COMPUTER_SWITCH", "stream-lifecycle": "STREAM_LIFECYCLE", "fork": "FORK", "file-listing": "FILE_LISTING", "hook-review": "HOOK_REVIEW"}[suite]
if args.app_store_ref:
    artifact_prefix += "_BASELINE"
root = Path(__file__).resolve().parents[2]
core = root / "ios/ZCodeMobile/Core"
audit = root / "docs/audit"
sources = [core / n for n in ("AppStore.swift", "PendingSubmission.swift", "Models.swift", "BridgeClient.swift", "ReferenceData.swift")]
sources += [root / "ios/ZCodeMobile/Features/ComposerView.swift"]
if suite in ("unread", "metadata-actions", "computer-switch"):
    sources += [root / "ios/ZCodeMobile/Features/HomeView.swift", root / "ios/ZCodeMobile/Design/SessionContextInteraction.swift"]
file_view_source = root / "ios/ZCodeMobile/Features/FilesView.swift"
if suite == "file-listing":
    sources.append(file_view_source)
dependencies = [core / "RemoteTransport.swift"] + [core / "Relay" / n for n in ("RelayTypes.swift", "RelayFrames.swift", "RelayProjection.swift", "RelayHostActivity.swift", "RelayCodec.swift")]
if (core / "Relay/RelayHookReview.swift").exists():
    dependencies.append(core / "Relay/RelayHookReview.swift")
if (core / "DraftAttachmentJournal.swift").exists():
    dependencies.append(core / "DraftAttachmentJournal.swift")
sources += dependencies
outbox_fixture_source = root / "scripts/tests/OutboxStateTests.swift"
test_source = root / "scripts/tests" / {"outbox": "OutboxStateTests.swift", "session-pagination": "SessionPaginationStateTests.swift", "unread": "UnreadStateTests.swift", "metadata-actions": "MetadataActionStateTests.swift", "computer-switch": "ComputerSwitchStateTests.swift", "stream-lifecycle": "StreamLifecycleStateTests.swift", "fork": "ForkStateTests.swift", "file-listing": "FileListingStateTests.swift", "hook-review": "HookReviewStateTests.swift"}[suite]
relay_stub_source = root / "scripts/tests/HostActivityStateTests.swift"
sources += [test_source, relay_stub_source]
sources.append(Path(__file__).resolve())
if suite == "computer-switch":
    sources += [root / "scripts/tests/run-computer-switch-tests.py", root / "ios/ZCodeMobile/App/AppShell.swift", root / "ios/ZCodeMobile/Features/ConnectionViews.swift"]
if uses_shared_fixtures:
    sources.append(outbox_fixture_source)
contents = {p: p.read_bytes() for p in sources}
app_store_revision = None
if args.app_store_ref:
    app_store_revision = subprocess.run(["git", "rev-parse", "--verify", args.app_store_ref + "^{commit}"], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
    contents[core / "AppStore.swift"] = subprocess.run(["git", "show", app_store_revision + ":ios/ZCodeMobile/Core/AppStore.swift"], cwd=root, capture_output=True, check=True).stdout
manifest = {str(p.relative_to(root)): hashlib.sha256(contents[p]).hexdigest() for p in sources}
start = datetime.now(timezone.utc).isoformat()
with tempfile.TemporaryDirectory(prefix=f"zcode-{suite}-tests-") as raw:
    temp = Path(raw)
    swift_inputs = []
    for name in ("AppStore.swift", "PendingSubmission.swift", "Models.swift", "ReferenceData.swift"):
        text = contents[core / name].decode()
        if name == "AppStore.swift":
            assert text.count("import UIKit") == 1
            assert text.count("private let submissionJournal = SubmissionJournal()") == 1
            text = text.replace("import UIKit", "// UIKit is replaced by inert test-only adapters.")
            text = text.replace("private let submissionJournal = SubmissionJournal()", "private let submissionJournal = SubmissionJournal(directory: OutboxTestSandbox.directory)")
            text = text.replace("DraftAttachmentJournal()", "DraftAttachmentJournal(directory: OutboxTestSandbox.directory.appendingPathComponent(\"draft-attachments\"))")
        target = temp / name
        target.write_text(text)
        swift_inputs.append(str(target))
    bridge = contents[core / "BridgeClient.swift"].decode()
    dto = bridge.split("struct BridgeClient: Sendable {", 1)[0]
    dto += "\n" + bridge.split("extension Date {", 1)[1].split("enum CredentialStore {", 1)[0]
    # Restore the declaration removed by split, leaving its body unchanged.
    dto = dto.replace("\n\n    static func fromBridge", "\n\nextension Date {\n    static func fromBridge", 1)
    target = temp / "ProductionDTOs.swift"
    target.write_text(dto)
    swift_inputs.append(str(target))
    for source in dependencies:
        target = temp / source.name
        target.write_bytes(contents[source])
        swift_inputs.append(str(target))
    if suite == "file-listing":
        helpers = contents[file_view_source].decode().split("struct FilesView: View {", 1)
        assert len(helpers) == 2
        target = temp / "ProductionFileTree.swift"
        target.write_text(helpers[0].replace("import SwiftUI", "import Foundation", 1))
        swift_inputs.append(str(target))
    # New production AppStore references relay pairing types. The same throwing
    # adapters used by the activity harness prohibit all real relay I/O here.
    relay_stubs = contents[relay_stub_source].decode().split("@main struct HostActivityStateTests {", 1)
    assert len(relay_stubs) == 2
    target = temp / "InertRelayAdapters.swift"
    target.write_text(relay_stubs[0])
    swift_inputs.append(str(target))
    if uses_shared_fixtures:
        fixtures = contents[outbox_fixture_source].decode().split("@main struct OutboxStateTests {", 1)
        assert len(fixtures) == 2
        target = temp / "SharedStateFixtures.swift"
        target.write_text(fixtures[0])
        swift_inputs.append(str(target))
    target = temp / test_source.name
    target.write_bytes(contents[test_source])
    swift_inputs.append(str(target))
    compiler = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True, check=True).stdout.strip()
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    version = subprocess.run([compiler, "--version"], capture_output=True, text=True, check=True).stdout.strip()
    build = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temp / "module-cache"), *swift_inputs, "-o", str(temp / "outbox-tests")], text=True, capture_output=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(build.returncode)
    run = subprocess.run([str(temp / "outbox-tests"), str(temp / "state"), str(temp / "results.json")], text=True, capture_output=True, timeout=90)
    output = run.stdout + run.stderr
    print(output, end="")
    report = json.loads((temp / "results.json").read_text()) if (temp / "results.json").exists() else {"harnessError": output}
    report.update(startedAt=start, completedAt=datetime.now(timezone.utc).isoformat(), swiftVersion=version, compiler=compiler, sdk=sdk, sourceSHA256=manifest, processExit=run.returncode)
    if app_store_revision:
        report["appStoreGitRevision"] = app_store_revision
    audit.mkdir(exist_ok=True)
    (audit / f"{artifact_prefix}_TEST_RESULTS.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (audit / f"{artifact_prefix}_TEST_OUTPUT.txt").write_text(output)
    sys.exit(run.returncode)
