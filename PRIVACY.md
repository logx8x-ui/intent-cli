# Intent Privacy

Intent is local-first software. It does not collect analytics, sell data, or send browsing history to Logan Mondi. The complete app can be used as a guest without creating an account.

Optional Intent accounts use Supabase Authentication for email/password or Google sign-in. When signed in, Intent syncs intentions, restrictions, frictions, schedules, portable settings, and the selected custom background so the same workspace can be used on another device. Each account's cloud row is protected by Row Level Security and can be read or changed only by that authenticated user. Authentication sessions are stored in the macOS Keychain. Passwords and Google credentials are handled by Supabase and Google; Intent does not store the user's password.

Guest data remains on the current Mac under `~/.intent`. Signed-in accounts use an isolated local cache under `~/.intent/accounts/<user-id>` for offline use. Intent does not automatically copy a guest workspace into a newly created account. Active sessions, cooldown timestamps, OS permissions, browser runtime state, calendar tokens, and AI draft history are device-local and are not account-synced.

The optional AI intention builder sends the activity description the user enters and the names and bundle identifiers of installed applications to Intent's hosted AI service, which uses OpenRouter to generate suggestions. Nothing is sent until the user submits the AI prompt, and every suggestion can be reviewed before it is saved. Intent sends a random installation identifier for rate limiting; it is not tied to an account or identity. AI requests are restricted to zero-data-retention providers that do not use submitted data for training. AI draft history stays on the Mac under `~/.intent/ai-history.json`.

Optional Apple Calendar and Google Calendar connections are off by default. Intent requests calendar access only after the user chooses Connect. Calendar event titles and contents are never sent to the Intent AI service. Google OAuth tokens are stored in the macOS Keychain, not in JSON files. Disconnecting a provider keeps local Intent schedules.

For Google Calendar, Intent requests permission to view the list of calendars the user subscribes to and to view, create, update, and delete calendar events. Intent does not request permission to change calendar sharing, subscription, or access-control settings, and it does not delete calendars.

The Intent Browser Guard extensions read the active tab URL only to apply the website rules chosen in the Intent Mac app. Browser rules and extension status travel only between the extension and Intent's native helper on the same computer.

Intentions, schedules, settings, and custom background images are stored locally on the user's Mac. They are also stored in the user's private cloud workspace only while the user is signed into an Intent account. Removing the app does not automatically delete an optional cloud account or its synced data.

Questions can be opened as a [GitHub issue](https://github.com/logx8x-ui/intent-cli/issues).
