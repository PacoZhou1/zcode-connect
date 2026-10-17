#!/bin/sh
set -eu

if ! command -v gitleaks >/dev/null 2>&1; then
  echo 'Install Gitleaks first: brew install gitleaks' >&2
  exit 2
fi

project_root=$(git rev-parse --show-toplevel)
gitleaks git --config "$project_root/.gitleaks.toml" --log-opts="--all" --redact=100 --no-banner "$project_root"
