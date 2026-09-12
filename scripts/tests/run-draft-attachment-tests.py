#!/usr/bin/env python3
"""Independent Foundation tests. No iOS build, UI, service, network or live draft data."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
paths = [root / "ios/ZCodeMobile/Core" / name for name in ("Models.swift", "DraftAttachmentJournal.swift")]
paths.append(root / "scripts/tests/DraftAttachmentJournalTests.swift")
snapshots = {p: p.read_bytes() for p in paths}
started = datetime.now(timezone.utc).isoformat()
with tempfile.TemporaryDirectory(prefix="zcode-draft-attachment-tests-") as raw:
    temp = Path(raw)
    for path, data in snapshots.items():
        (temp / path.name).write_bytes(data)
    compiler = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True, check=True).stdout.strip()
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
    build = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "6", "-parse-as-library", "-O", "-module-cache-path", str(temp / "module-cache"), *[str(temp / p.name) for p in paths], "-o", str(temp / "tests")], text=True, capture_output=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(build.returncode)
    run = subprocess.run([str(temp / "tests"), str(temp / "files"), str(temp / "results.json")], text=True, capture_output=True)
    output = run.stdout + run.stderr
    print(output, end="")
    results = json.loads((temp / "results.json").read_text())
    report = dict(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), cases=len(results), passed=sum(r["passed"] for r in results), failed=sum(not r["passed"] for r in results), results=results, sourceSHA256={str(p.relative_to(root)): hashlib.sha256(data).hexdigest() for p, data in snapshots.items()}, compiler=compiler, sdk=sdk, processExit=run.returncode)
    audit = root / "docs/audit"
    (audit / "DRAFT_ATTACHMENT_TEST_RESULTS.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    (audit / "DRAFT_ATTACHMENT_TEST_OUTPUT.txt").write_text(output)
    sys.exit(run.returncode)
