#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export INTENT_ALLOW_UNSIGNED_LOCAL=1
exec "$ROOT/scripts/build-release.sh" "$@"
