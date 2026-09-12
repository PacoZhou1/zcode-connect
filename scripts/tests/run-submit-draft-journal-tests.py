#!/usr/bin/env python3
"""Exercise the exact production submitDraft body with counted, fallible durable writes.

Only network collaborators are inert. PendingSubmission, SubmissionJournal and the
related value types are extracted unchanged from production; all files use a
temporary directory. No App, Simulator, service, account or model is contacted.
"""
from datetime import datetime, timezone
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", action="store_true", help="Keep a distinct pre-fix evidence artifact")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
core = root / "ios/ZCodeMobile/Core"
test = root / "scripts/tests/SubmitDraftJournalTests.swift"
paths = [core / name for name in ("AppStore.swift", "PendingSubmission.swift", "BridgeClient.swift", "Models.swift")] + [test, Path(__file__).resolve()]
contents = {p: p.read_bytes() for p in paths}
manifest = {str(p.relative_to(root)): hashlib.sha256(data).hexdigest() for p, data in contents.items()}

def between(source, start, end):
    assert source.count(start) == 1, start
    tail = source.split(start, 1)[1]
    assert end in tail, end
    return start + tail.split(end, 1)[0]

app = contents[core / "AppStore.swift"].decode()
method = between(app, "    func submitDraft(", "    var effectiveNewModelSelection:")
bridge = contents[core / "BridgeClient.swift"].decode()
models = contents[core / "Models.swift"].decode()
values = "import Foundation\n" + between(bridge, "enum JSONValue:", "struct RemoteModel:")
values += between(bridge, "struct ModelSelection:", "struct RemoteSettings:")
values += between(models, "struct MessageForkTarget:", "struct ChatMessage:")
values += between(models, "enum PermissionMode:", "struct SessionOptions:")
attachment_start = models.index("struct Attachment:")
values += models[attachment_start:models.index("\n}", attachment_start) + 3]
started = datetime.now(timezone.utc).isoformat()

with tempfile.TemporaryDirectory(prefix="zcode-submit-journal-tests-") as raw:
    temp = Path(raw)
    inputs = {
        "ProductionSubmitDraft.swift": "import Foundation\nextension SubmitDraftHarness {\n" + method + "}\n",
        "ProductionValues.swift": values,
        "PendingSubmission.swift": contents[core / "PendingSubmission.swift"].decode(),
        test.name: contents[test].decode(),
    }
    for name, source in inputs.items():
        (temp / name).write_text(source)
    compiler = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True, check=True).stdout.strip()
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    version = subprocess.run([compiler, "--version"], capture_output=True, text=True, check=True).stdout.strip()
    build = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temp / "module-cache"), *[str(temp / name) for name in inputs], "-o", str(temp / "tests")], capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(build.returncode)
    run = subprocess.run([str(temp / "tests"), str(temp / "state"), str(temp / "results.json")], capture_output=True, text=True, timeout=60)
    output = run.stdout + run.stderr
    print(output, end="")
    report = json.loads((temp / "results.json").read_text()) if (temp / "results.json").exists() else {"harnessError": output}
    report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), swiftVersion=version,
                  sourceSHA256=manifest, extractedMethodSHA256=hashlib.sha256(method.encode()).hexdigest(),
                  processExit=run.returncode, scope="Production submitDraft and real file journal; inert create/send only")
    audit = root / "docs/audit"
    audit.mkdir(exist_ok=True)
    prefix = "SUBMIT_DRAFT_JOURNAL_BASELINE" if args.baseline else "SUBMIT_DRAFT_JOURNAL"
    (audit / f"{prefix}_TEST_RESULTS.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (audit / f"{prefix}_TEST_OUTPUT.txt").write_text(output)
    sys.exit(run.returncode)
