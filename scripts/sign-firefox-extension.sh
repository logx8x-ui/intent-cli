#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${AMO_JWT_ISSUER:-}" || -z "${AMO_JWT_SECRET:-}" ]]; then
  cat >&2 <<'MSG'
Missing Mozilla Add-ons signing credentials.

Create AMO API credentials at:
https://addons.mozilla.org/en-US/developers/addon/api/key/

Then run:
export AMO_JWT_ISSUER='user:...'
export AMO_JWT_SECRET='...'
./scripts/sign-firefox-extension.sh
MSG
  exit 2
fi

npm run test:firefox
npm run extension:lint
npm run extension:sign:listed
