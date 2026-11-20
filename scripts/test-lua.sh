#!/usr/bin/env bash
# Runs every Lua spec in a clean headless Neovim. A spec fails by raising an error.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
status=0
for spec in "$root"/tests/lua/*_spec.lua; do
  if ! nvim --headless -u NONE -i NONE -l "$spec"; then
    echo "FAILED: ${spec#"$root"/}" >&2
    status=1
  fi
done
exit "$status"
