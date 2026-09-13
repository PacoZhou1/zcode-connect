#!/bin/bash
set -euo pipefail
self_hosted_adapter="$(cd -- "$(dirname -- "$0")" && pwd)"
self_hosted_core="$(cd -- "$self_hosted_adapter/.." && pwd)"
self_hosted_build="$(mktemp -d "${TMPDIR:-/tmp}/zcode-self-hosted-tests.XXXXXX")"
trap 'rm -rf -- "$self_hosted_build"' EXIT
self_hosted_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$self_hosted_sdk" -swift-version 6 -warnings-as-errors -D RELAY_SELF_HOSTED_SELF_TESTS \
  "$self_hosted_core/Models.swift" "$self_hosted_core/BridgeClient.swift" "$self_hosted_core/ServerSentEvents.swift" "$self_hosted_core/RemoteTransport.swift" \
  "$self_hosted_core/Relay/"*.swift "$self_hosted_adapter/"*.swift -o "$self_hosted_build/self-hosted-tests"
"$self_hosted_build/self-hosted-tests" "${1:?Use an explicit evidence JSON path}"
