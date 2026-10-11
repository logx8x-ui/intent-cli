#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-profile-spec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library "$ROOT/Sources/IntentApp/IntentBrowserProfiles.swift" \
  "$ROOT/scripts/test-browser-profile-setup.swift" -o "$WORK/profile-spec"
"$WORK/profile-spec"
