#!/bin/bash
set -euo pipefail

# Compile a snapshot of the production decoder; no Xcode, Simulator, or network.
sse_test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
sse_project_root="$(CDPATH= cd -- "$sse_test_dir/../.." && pwd)"
sse_source="$sse_project_root/ios/ZCodeMobile/Core/ServerSentEvents.swift"
sse_audit_dir="$sse_project_root/docs/audit"
sse_temp_dir="$(mktemp -d /tmp/zcode-sse-tests.XXXXXX)"
trap 'rm -rf -- "$sse_temp_dir"' EXIT

mkdir -p "$sse_audit_dir"
cp "$sse_source" "$sse_temp_dir/ServerSentEvents.swift"
sse_source_sha="$(shasum -a 256 "$sse_temp_dir/ServerSentEvents.swift" | awk '{print $1}')"
sse_swift_version="$(swiftc --version 2>&1)"

swiftc -swift-version 6 -parse-as-library -O \
  -module-cache-path "$sse_temp_dir/module-cache" \
  "$sse_temp_dir/ServerSentEvents.swift" \
  "$sse_test_dir/ServerSentEventsDecoderTests.swift" \
  -o "$sse_temp_dir/sse-decoder-tests"

"$sse_temp_dir/sse-decoder-tests" \
  --source "$sse_source" \
  --source-sha "$sse_source_sha" \
  --swift-version "$sse_swift_version" \
  --report "$sse_audit_dir/SSE_DECODER_TEST_RESULTS.json" \
  "$@" | tee "$sse_audit_dir/SSE_DECODER_TEST_OUTPUT.txt"
