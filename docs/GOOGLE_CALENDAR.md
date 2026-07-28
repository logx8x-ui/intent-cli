# Google Calendar setup for Intent

Intent’s scheduler works fully without Google. Google Calendar is optional.

## What Intent needs

A **public** OAuth 2.0 client ID for a native macOS app (PKCE).  
Do **not** put a client secret in the app.

## Account-owner steps

1. In [Google Cloud Console](https://console.cloud.google.com/), create or choose a project.
2. Enable the **Google Calendar API** (and optionally **Google Tasks API** for read-only tasks).
3. Configure the OAuth consent screen.
4. Create an OAuth client of type **Desktop app** / **iOS** / native with redirect URI:

   `intent://oauth/google`

5. Copy the **Client ID** only (no secret).
6. Either:

   - Set `INTENT_GOOGLE_CLIENT_ID` in the environment when launching Intent, or
   - Copy `Sources/IntentApp/Resources/GoogleCalendarConfig.plist.example` to  
     `Sources/IntentApp/Resources/GoogleCalendarConfig.plist` and replace `YOUR_GOOGLE_OAUTH_CLIENT_ID`.

7. Rebuild / reinstall the development app with `./scripts/install-dev.sh`.

Tokens are stored in the macOS Keychain under service `dev.loganmondi.intent.calendar`.  
They are never written to `~/.intent` JSON files or sent to Intent AI.
