# Intent Accounts

Intent works without an account. Guest mode keeps the complete app and stores
its workspace only under `~/.intent` on the current Mac.

An Intent account adds cross-device sync. Each account has an isolated local
cache under `~/.intent/accounts/<user-id>` and a private cloud row protected by
Supabase Row Level Security. Signing into a new account never imports the guest
workspace automatically, so a newly created account begins with zero
intentions. Signing out restores the guest workspace.

## Synced

- intentions and their graph positions
- restrictions and frictions
- schedules
- appearance, canvas title, background choice, and custom background image
- onboarding state and portable Intent shortcuts

## Kept on each Mac

- active sessions, cooldown timestamps, and Zero Drift runtime state
- macOS Accessibility, microphone, calendar, and launch-at-login permissions
- browser-native-host runtime state
- Google Calendar OAuth tokens
- AI installation identifiers and draft history

## Backend setup

1. Create a Supabase project.
2. Run `supabase/migrations/001_intent_user_state.sql` in its SQL editor.
3. Enable Email and Google under Authentication providers.
4. Add both `intent://auth-callback` and `intent://password-reset` to
   Authentication URL Configuration redirect URLs.
5. For Google, add Supabase's callback URL to the Google OAuth client and copy
   the Google client ID and secret into the Supabase Google provider.
6. Supply the project URL and publishable client key through
   `INTENT_SUPABASE_URL` and `INTENT_SUPABASE_PUBLISHABLE_KEY` when installing
   a development build or packaging a release. The build scripts inject them
   into the app's private resource bundle without changing tracked source.

The Supabase publishable key is designed for client apps and is protected by
Row Level Security. Never place a Supabase service-role key or Google client
secret in the app, plist, repository, or release bundle.

For local testing, configuration can instead be supplied without editing files:

```zsh
export INTENT_SUPABASE_URL='https://your-project-ref.supabase.co'
export INTENT_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'
swift run IntentApp
```

The same two environment variables work with `./scripts/install-dev.sh` and
`./scripts/build-release.sh`. A distributable release is refused if they are
missing. An unsigned local QA build may omit them and remains guest-only.
