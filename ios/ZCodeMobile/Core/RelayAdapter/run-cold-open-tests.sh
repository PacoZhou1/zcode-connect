#!/bin/bash
set -euo pipefail
relay_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_core_dir="$(cd -- "$relay_adapter_dir/.." && pwd)"
relay_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-cold-open.XXXXXX")"
trap 'rm -rf -- "$relay_build_dir"' EXIT
relay_sources=("$relay_core_dir/Models.swift" "$relay_core_dir/BridgeClient.swift" "$relay_core_dir/ServerSentEvents.swift" "$relay_core_dir/RemoteTransport.swift" "$relay_core_dir/Relay/"*.swift)
for relay_source in "$relay_adapter_dir/"*.swift; do
  if [[ -n "${2:-}" && "$relay_source" == "$relay_adapter_dir/RelayRemoteTransport.swift" ]]; then
    relay_sources+=("$2")
  else
    relay_sources+=("$relay_source")
  fi
done
relay_macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$relay_macos_sdk" -swift-version 6 -warnings-as-errors -D RELAY_COLD_OPEN_SELF_TESTS "${relay_sources[@]}" -o "$relay_build_dir/cold-open-tests"
"$relay_build_dir/cold-open-tests" "${1:?Use an explicit evidence JSON path}"
