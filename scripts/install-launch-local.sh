#!/usr/bin/env bash
set -euo pipefail
# Explicit source-built launch-channel QA install; never a distributable release.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/scripts/install-dev.sh" --launch-local "$@"
