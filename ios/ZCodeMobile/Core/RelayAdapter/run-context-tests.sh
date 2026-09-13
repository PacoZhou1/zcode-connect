#!/bin/bash
set -euo pipefail
context_adapter_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
context_core_dir="$(cd -- "$context_adapter_dir/.." && pwd)"
context_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/zcode-context-tests.XXXXXX")"
trap 'rm -rf -- "$context_build_dir"' EXIT
context_sources=("$context_core_dir/Models.swift" "$context_core_dir/BridgeClient.swift" "$context_core_dir/ServerSentEvents.swift" "$context_core_dir/RemoteTransport.swift" "$context_core_dir/Relay/"*.swift "$context_adapter_dir/"*.swift)
context_snapshot_sources=()
for context_source in "${context_sources[@]}"; do
  context_snapshot="$context_build_dir/$(basename "$context_source")"
  cp "$context_source" "$context_snapshot"
  context_snapshot_sources+=("$context_snapshot")
done
python3 - "$context_build_dir" "${1:?Use an explicit evidence JSON path}.sources.json" <<'PY'
from pathlib import Path
import sys,json,hashlib
files=Path(sys.argv[1]).glob('*.swift')
Path(sys.argv[2]).write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2)+'\n')
PY
context_macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -sdk "$context_macos_sdk" -swift-version 6 -warnings-as-errors -D RELAY_CONTEXT_SELF_TESTS "${context_snapshot_sources[@]}" -o "$context_build_dir/context-tests"
"$context_build_dir/context-tests" "${1:?Use an explicit evidence JSON path}" "${2:?Use the installed-source fixture JSON path}"
