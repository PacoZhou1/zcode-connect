#!/bin/bash
set -euo pipefail
relay_source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_project_dir="$(cd -- "$relay_source_dir/../../../.." && pwd)"
relay_evidence_dir="${1:-$relay_project_dir/tests/fixtures/relay}"
relay_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay.XXXXXX")"
trap 'rm -rf -- "$relay_build_dir"' EXIT
swiftc -swift-version 6 -warnings-as-errors -D RELAY_SELF_TESTS "$relay_source_dir"/*.swift -o "$relay_build_dir/self-tests"
mkdir "$relay_build_dir/fixtures"
cp "$relay_evidence_dir/"*.json "$relay_build_dir/fixtures/"
"$relay_build_dir/self-tests" "$relay_build_dir/fixtures"
relay_ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -emit-module -module-name ZCodeRelay \
  -target arm64-apple-ios26.0 -sdk "$relay_ios_sdk" "$relay_source_dir"/*.swift \
  -emit-module-path "$relay_build_dir/ZCodeRelay.swiftmodule"
printf '%s\n' 'Swift 6 / iOS 26 arm64 module compilation passed. No account, simulator, or device was connected.'
