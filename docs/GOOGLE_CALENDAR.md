# Google Calendar setup for Intent

Intent’s scheduler works fully without Google. Google Calendar is optional.

## What Intent needs

A **public** OAuth 2.0 client ID for a native macOS app (PKCE).  
Do **not** put a client secret in the app.

## Account-owner steps

1. In [Google Cloud Console](https://console.cloud.google.com/), create or choose a project.
2. Enable the **Google Calendar API**.
3. Configure the OAuth consent screen.
4. Create an OAuth client of type **Desktop app**.

5. Copy the **Client ID** only (no secret).
6. Either:

   - Set `INTENT_GOOGLE_CLIENT_ID` in the environment when launching Intent, or
   - Copy `Sources/IntentApp/Resources/GoogleCalendarConfig.plist.example` to  
     `Sources/IntentApp/Resources/GoogleCalendarConfig.plist` and replace `YOUR_GOOGLE_OAUTH_CLIENT_ID`.

7. Rebuild / reinstall the development app with `./scripts/install-dev.sh`.

When the user clicks **Connect**, Intent opens Google sign-in in their normal
browser and receives the result through a temporary loopback address on this
Mac. No custom URL scheme or client secret is required.

Tokens are stored in the macOS Keychain under service `dev.loganmondi.intent.calendar`.  
They are never written to `~/.intent` JSON files or sent to Intent AI.

Intent requests only these Google permissions:

- `calendar.calendarlist.readonly` to show the user's available calendars.
- `calendar.events` to display events and sync Intent schedules.

Intent does not request permission to manage calendar sharing or delete calendars.

Public releases must also complete Google OAuth verification. See
[`GOOGLE_OAUTH_VERIFICATION.md`](GOOGLE_OAUTH_VERIFICATION.md) for the exact
production checklist and scope justification.
