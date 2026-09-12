#!/bin/bash
set -euo pipefail
relay_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_core_dir="$(cd -- "$relay_adapter_dir/.." && pwd)"
relay_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-adapter.XXXXXX")"
trap 'rm -rf -- "$relay_build_dir"' EXIT
relay_sources=("$relay_core_dir/Models.swift" "$relay_core_dir/BridgeClient.swift" "$relay_core_dir/ServerSentEvents.swift" "$relay_core_dir/RemoteTransport.swift" "$relay_core_dir/Relay/"*.swift "$relay_adapter_dir/"*.swift)
swiftc -swift-version 6 -warnings-as-errors -D RELAY_ADAPTER_SELF_TESTS "${relay_sources[@]}" -o "$relay_build_dir/self-tests"
"$relay_build_dir/self-tests" "${1:-/Users/developer/claude code/zcode-mobile/docs/backend/evidence}"
relay_ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -emit-module -module-name ZCodeRelayFacade \
  -target arm64-apple-ios26.0 -sdk "$relay_ios_sdk" "${relay_sources[@]}" -emit-module-path "$relay_build_dir/ZCodeRelayFacade.swiftmodule"
printf '%s\n' 'Swift 6 / iOS 26 arm64 facade compilation passed. No real account or simulator was connected.'
