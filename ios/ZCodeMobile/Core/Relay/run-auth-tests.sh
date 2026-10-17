#!/bin/bash
set -euo pipefail
relay_auth_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
relay_auth_root="$(cd -- "$relay_auth_dir/../../../.." && pwd)"
relay_auth_build="$(mktemp -d "${TMPDIR:-/tmp}/zcode-relay-auth.XXXXXX")"
trap 'rm -rf -- "$relay_auth_build"' EXIT
relay_auth_sources=()
for relay_auth_source in "$relay_auth_dir/"*.swift; do
  if [[ -n "${2:-}" && "$(basename -- "$relay_auth_source")" == "RelayClient.swift" ]]; then continue; fi
  relay_auth_sources+=("$relay_auth_source")
done
if [[ -n "${2:-}" ]]; then relay_auth_sources+=("$2"); fi
relay_auth_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$relay_auth_sdk" -swift-version 6 -warnings-as-errors -D RELAY_AUTH_SELF_TESTS "${relay_auth_sources[@]}" -o "$relay_auth_build/auth-tests"
"$relay_auth_build/auth-tests" "$relay_auth_root/tests/fixtures/relay/relay-auth-official-vectors.json" "${1:-$relay_auth_build/results.json}"
