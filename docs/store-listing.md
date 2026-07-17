# Intent Browser Guard Store Listing

## Name

Intent Browser Guard

## Summary

Applies the website rules from an active Intent focus session in Firefox or Chrome.

## Description

Intent Browser Guard is the browser companion for the Intent macOS focus app.

Leave the guard switched on and it listens locally for an active intention. While no intention is running, it does nothing. During a session it allows only the websites selected in Intent, keeps allowed tabs usable, and optionally permits browser search-result pages.

Intent Browser Guard has one purpose: enforce the browser portion of an Intent session. It contains no ads, analytics, accounts, or remote code.

## Category

Productivity

## Privacy

- No user data is collected or sold.
- URLs are checked locally and are not transmitted to a remote server.
- Native messaging is used only to communicate with the installed Intent app on the same computer.

Privacy policy: https://github.com/logx8x-ui/intent-cli/blob/main/PRIVACY.md

## Permission Justifications

- `tabs` and `webNavigation`: detect tab changes and navigation while an active intention is running.
- `webRequest` / `declarativeNetRequest`: stop navigation outside the active intention's local allowlist.
- `nativeMessaging`: receive active rules from the Intent desktop app.
- `storage`: remember the user's on/off switch after browser or computer restarts.
- broad host access: required because users choose their own allowed websites inside Intent.
