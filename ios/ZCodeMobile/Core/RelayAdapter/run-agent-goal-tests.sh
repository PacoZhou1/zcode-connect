#!/bin/bash
set -euo pipefail
relay_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_core_dir="$(cd -- "$relay_adapter_dir/.." && pwd)"
relay_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-agent-goal.XXXXXX")"
trap 'rm -rf -- "$relay_build_dir"' EXIT
relay_sources=("$relay_core_dir/Models.swift" "$relay_core_dir/BridgeClient.swift" "$relay_core_dir/ServerSentEvents.swift" "$relay_core_dir/RemoteTransport.swift")
for relay_source in "$relay_core_dir/Relay/"*.swift "$relay_adapter_dir/"*.swift; do
  if [[ -n "${2:-}" && -f "$2/$(basename "$relay_source")" ]]; then relay_sources+=("$2/$(basename "$relay_source")"); else relay_sources+=("$relay_source"); fi
done
relay_macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$relay_macos_sdk" -swift-version 6 -warnings-as-errors -D RELAY_AGENT_GOAL_SELF_TESTS "${relay_sources[@]}" -o "$relay_build_dir/agent-goal-tests"
"$relay_build_dir/agent-goal-tests" "${1:?Use an explicit evidence JSON path}"
