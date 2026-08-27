#!/bin/zsh

set -euo pipefail

project_ref="${INTENT_SUPABASE_PROJECT_REF:-cwfbvvrmnnfhzpkhbckc}"

: "${SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID:?Set SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID first.}"
: "${SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET:?Set SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET first.}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

npx --yes supabase@latest config push --project-ref "$project_ref"

echo "Google account sign-in configuration was pushed to Supabase."
