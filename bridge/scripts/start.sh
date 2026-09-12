#!/bin/zsh
set -eu
bridge_root="${0:A:h:h}"
cd "$bridge_root"
exec node src/server.mjs
