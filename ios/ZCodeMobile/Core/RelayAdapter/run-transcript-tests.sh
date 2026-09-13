#!/bin/bash
set -euo pipefail
transcript_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
transcript_core_dir="$(cd -- "$transcript_adapter_dir/.." && pwd)"
transcript_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-transcript-tests.XXXXXX")"
trap 'rm -rf -- "$transcript_build_dir"' EXIT
transcript_sources=("$transcript_core_dir/Models.swift" "$transcript_core_dir/BridgeClient.swift" "$transcript_core_dir/ServerSentEvents.swift" "$transcript_core_dir/RemoteTransport.swift" "$transcript_core_dir/TranscriptPresentation.swift" "$transcript_core_dir/Relay/"*.swift "$transcript_adapter_dir/"*.swift)
transcript_macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$transcript_macos_sdk" -swift-version 6 -warnings-as-errors -D RELAY_TRANSCRIPT_SELF_TESTS "${transcript_sources[@]}" -o "$transcript_build_dir/transcript-tests"
"$transcript_build_dir/transcript-tests" "${1:?Use an explicit evidence JSON path}"
