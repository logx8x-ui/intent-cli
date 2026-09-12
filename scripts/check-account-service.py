#!/usr/bin/env python3
"""Release gate: probe the configured public account service without credentials in logs."""
import json, os, pathlib, plistlib, sys, urllib.request, urllib.error
config = {}
path = pathlib.Path.home() / 'Applications/Intent.app/Contents/Resources/Intent_IntentApp.bundle/SupabaseConfig.plist'
if path.exists():
    with path.open('rb') as file: config = plistlib.load(file)
url = os.environ.get('INTENT_SUPABASE_URL') or config.get('SUPABASE_URL')
key = os.environ.get('INTENT_SUPABASE_PUBLISHABLE_KEY') or config.get('SUPABASE_PUBLISHABLE_KEY')
if not url or not key: sys.exit('Account service configuration is missing.')
try:
    request = urllib.request.Request(url.rstrip('/') + '/auth/v1/settings', headers={'apikey': key})
    with urllib.request.urlopen(request, timeout=12) as response: settings = json.load(response)
    if settings.get('external', {}).get('google') is not True: sys.exit('Google provider is disabled.')
    if settings.get('disable_signup') is True: sys.exit('New account creation is disabled.')
    print('Account service reachable; Google provider and new account creation enabled. OAuth consent/callback still requires live acceptance.')
except (OSError, ValueError):
    sys.exit('Account service is unavailable. Restore the configured Supabase project before releasing.')
