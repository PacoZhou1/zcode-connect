#!/bin/bash
set -euo pipefail
relay_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_core_dir="$(cd -- "$relay_adapter_dir/.." && pwd)"
relay_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-recovery.XXXXXX")"
trap 'rm -rf -- "$relay_build_dir"' EXIT
relay_sources=("$relay_core_dir/Models.swift" "$relay_core_dir/BridgeClient.swift" "$relay_core_dir/ServerSentEvents.swift" "$relay_core_dir/RemoteTransport.swift" "$relay_core_dir/Relay/"*.swift "$relay_adapter_dir/"*.swift)
relay_macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$relay_macos_sdk" -swift-version 6 -warnings-as-errors -D RELAY_RECOVERY_SELF_TESTS "${relay_sources[@]}" -o "$relay_build_dir/recovery-tests"
"$relay_build_dir/recovery-tests" "$@"
