#!/usr/bin/env python3
"""Compile the real attachment decoder/cache independently, without UIKit or network."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[2]
source = root / "ios/ZCodeMobile/Features/MessageAttachmentView.swift"
tests = Path(__file__).with_name("AttachmentPreviewCacheTests.swift")
text = source.read_text()
worker = text.split("private struct AttachmentPreviewRequest:", 1)[1].split("private struct AttachmentImagePreview:", 1)[0]
worker = "private struct AttachmentPreviewRequest:" + worker
started = datetime.now(timezone.utc).isoformat()
with tempfile.TemporaryDirectory(prefix="zcode-preview-cache-tests-") as raw:
    temp = Path(raw)
    combined = temp / "PreviewCacheTests.swift"
    combined.write_text("import Foundation\nimport CoreGraphics\nimport ImageIO\nimport CryptoKit\n" + worker + "\n" + tests.read_text())
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
    binary = temp / "preview-tests"
    build = subprocess.run([compiler, "-sdk", sdk, "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors", "-parse-as-library", "-O", "-module-cache-path", str(temp / "cache"), str(combined), "-o", str(binary)], capture_output=True, text=True)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(build.returncode)
    result = subprocess.run([str(binary), str(temp / "report.json")], capture_output=True, text=True, timeout=60)
    output = result.stdout + result.stderr
    print(output, end="")
    report = json.loads((temp / "report.json").read_text())
    report.update(startedAt=started, completedAt=datetime.now(timezone.utc).isoformat(), sourceSHA256=hashlib.sha256(text.encode()).hexdigest(), testSHA256=hashlib.sha256(tests.read_bytes()).hexdigest(), processExit=result.returncode)
    audit = root / "docs/audit"
    (audit / "ATTACHMENT_PREVIEW_TEST_RESULTS.json").write_text(json.dumps(report, indent=2) + "\n")
    (audit / "ATTACHMENT_PREVIEW_TEST_OUTPUT.txt").write_text(output)
    sys.exit(result.returncode)
