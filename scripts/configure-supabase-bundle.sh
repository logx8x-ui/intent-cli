#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <Intent_IntentApp.bundle> [require-config: 0|1]" >&2
  exit 64
fi

BUNDLE="$1"
REQUIRE_CONFIG="${2:-0}"
SUPABASE_URL="${INTENT_SUPABASE_URL:-}"
SUPABASE_KEY="${INTENT_SUPABASE_PUBLISHABLE_KEY:-}"
CONFIG="$BUNDLE/SupabaseConfig.plist"

if [[ -z "$SUPABASE_URL" ]]; then
  SUPABASE_URL="$(
    security find-generic-password \
      -s "dev.loganmondi.intent.build" \
      -a "supabase-url" \
      -w 2>/dev/null || true
  )"
fi

PLACEHOLDER_URL_PATTERN='YOUR_PROJECT|your-project|example[.]supabase[.]co'
PLACEHOLDER_KEY_PATTERN='YOUR_PUBLISHABLE_KEY|your-publishable-key|paste|placeholder'

if [[ -n "$SUPABASE_URL" ]] && printf '%s' "$SUPABASE_URL" | grep -Eqi "$PLACEHOLDER_URL_PATTERN"; then
  echo "Refusing placeholder INTENT_SUPABASE_URL. Supply the real project URL or leave both values unset for a guest-only build." >&2
  exit 70
fi

if [[ -z "$SUPABASE_KEY" ]]; then
  SUPABASE_KEY="$(
    security find-generic-password \
      -s "dev.loganmondi.intent.build" \
      -a "supabase-publishable-key" \
      -w 2>/dev/null || true
  )"
fi

if [[ -n "$SUPABASE_KEY" ]] && printf '%s' "$SUPABASE_KEY" | grep -Eqi "$PLACEHOLDER_KEY_PATTERN"; then
  echo "Refusing placeholder INTENT_SUPABASE_PUBLISHABLE_KEY. Supply the real public key or leave both values unset for a guest-only build." >&2
  exit 71
fi

if [[ -n "$SUPABASE_URL" && -z "$SUPABASE_KEY" ]] ||
   [[ -z "$SUPABASE_URL" && -n "$SUPABASE_KEY" ]]; then
  echo "Intent account configuration requires both INTENT_SUPABASE_URL and INTENT_SUPABASE_PUBLISHABLE_KEY." >&2
  exit 65
fi

if [[ -z "$SUPABASE_URL" ]]; then
  if [[ "$REQUIRE_CONFIG" == "1" ]]; then
    cat >&2 <<'MSG'
Release refused: Intent account sync is not configured.

Set the public client values:
  INTENT_SUPABASE_URL='https://your-project-ref.supabase.co'
  INTENT_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'

Never use a service-role or secret key here.
MSG
    exit 66
  fi
  echo "Intent account sync: guest-only build (no Supabase client configuration supplied)."
  exit 0
fi

if [[ "$SUPABASE_URL" != https://* ]]; then
  echo "INTENT_SUPABASE_URL must use HTTPS." >&2
  exit 67
fi

if [[ "$SUPABASE_URL" != *.supabase.co && "$SUPABASE_URL" != *.supabase.co/ ]]; then
  echo "INTENT_SUPABASE_URL must be a Supabase project URL ending in .supabase.co." >&2
  exit 72
fi

case "$SUPABASE_KEY" in
  sb_secret_*|*service_role*)
    echo "Refusing to embed a privileged Supabase key. Use the public publishable/anon client key." >&2
    exit 68
    ;;
esac

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing bundled SupabaseConfig.plist at $CONFIG" >&2
  exit 69
fi

/usr/bin/plutil -replace SUPABASE_URL -string "$SUPABASE_URL" "$CONFIG"
/usr/bin/plutil -replace SUPABASE_PUBLISHABLE_KEY -string "$SUPABASE_KEY" "$CONFIG"

echo "Intent account sync: public Supabase client configuration embedded."
