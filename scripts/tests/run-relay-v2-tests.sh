#!/bin/bash
set -euo pipefail
v2_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
v2_build="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-v2.XXXXXX")"
trap 'rm -rf -- "$v2_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors "$v2_root"/ios/ZCodeMobile/Core/Relay/*.swift \
  "$v2_root/ios/ZCodeMobile/Core/OfficialAccountController.swift" \
  "$v2_root/tests/relay-v2/RelayV2SelfTests.swift" -o "$v2_build/tests"
"$v2_build/tests" "$@"
