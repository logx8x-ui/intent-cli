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
    if settings.get('external', {}).get('email') is not True: sys.exit('Email sign-in is disabled.')
    if settings.get('disable_signup') is True: sys.exit('New account creation is disabled.')
    if settings.get('mailer_autoconfirm') is not False: sys.exit('Email verification must be required.')
    print('Account service reachable; email signup and verification enabled. Email delivery, code verification, and account sync still require live acceptance.')
except (OSError, ValueError):
    sys.exit('Account service is unavailable. Restore the configured Supabase project before releasing.')
