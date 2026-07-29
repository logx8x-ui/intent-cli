# Google OAuth production verification

Intent uses Google Calendar only when a user explicitly connects it from the
scheduler. The local scheduler works without Google.

## Production permissions

Intent requests the minimum permissions needed for calendar sync:

- `https://www.googleapis.com/auth/calendar.calendarlist.readonly`
- `https://www.googleapis.com/auth/calendar.events`

Intent does not request Calendar ACL, sharing, subscription-management, or
calendar-deletion permissions.

## Scope justification

Use this text in Google Auth Platform:

> Intent uses `calendar.calendarlist.readonly` to show the calendars available
> to the signed-in user inside Intent's scheduler. Intent uses
> `calendar.events` to display events and to create, update, or delete only the
> event records the user chooses to sync as Intent schedules. Calendar data
> remains on the user's Mac and is never sent to Intent AI. OAuth tokens are
> stored in the macOS Keychain. Intent does not access calendar sharing
> settings, calendar ACLs, or delete calendars.

## Required public pages

Google requires both pages to be public HTML on a domain owned by the
developer:

1. An Intent homepage that clearly describes the app and links to the privacy
   policy.
2. A dedicated privacy-policy page containing the disclosures in
   `PRIVACY.md`.

The domain must be verified in Google Search Console and added to Google Auth
Platform as an authorized domain.

## Google Auth Platform checklist

1. Set the audience to **External** and move the app to **Production**.
2. Complete Branding:
   - App name: `Intent`
   - User support email: `logx8x@gmail.com`
   - Developer contact email: `logx8x@gmail.com`
   - Intent app logo
   - Homepage URL on the verified domain
   - Privacy-policy URL on the verified domain
3. Add the verified domain under authorized domains.
4. Register only the two production permissions listed above.
5. Paste the scope justification above.
6. Record an unlisted OAuth demo video showing:
   - Opening Intent's scheduler.
   - Clicking **Connect Google Calendar**.
   - The complete Google consent flow.
   - Google calendars and events appearing inside Intent.
   - Creating or editing an Intent schedule and syncing the event.
   - Disconnecting Google Calendar.
7. Add the demo-video URL in Verification Center.
8. Submit the app for brand and sensitive-scope verification.

Google performs the final review. Until approval, Testing mode is limited to
manually listed test users, while an unverified Production app may show a
warning and remains subject to Google's unverified-user cap.
