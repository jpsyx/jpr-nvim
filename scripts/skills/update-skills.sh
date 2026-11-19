#!/usr/bin/env bash
#
# Updates every agent skill this project has. `npx skills` owns them all,
# through `skills-lock.json`.
#
# This script is the one place a skill update happens, so a project updates its
# skills the same way whatever language it is written in.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "Updating the skills in skills-lock.json..."
npx --yes skills update --project --yes </dev/null
