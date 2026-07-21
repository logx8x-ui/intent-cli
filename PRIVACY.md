# Intent Privacy

Intent is local-first software. It does not create an account, collect analytics, sell data, or send browsing history to Logan Mondi or another server.

The optional AI intention builder uses the user's own OpenAI API key. It sends OpenAI only the activity description the user enters and the names and bundle identifiers of installed applications so that it can suggest intentions. Nothing is sent until the user chooses **Suggest intentions**, and every suggestion can be reviewed before it is saved. The API key is stored in macOS Keychain and can be removed from the builder.

The Intent Browser Guard extensions read the active tab URL only to apply the website rules chosen in the Intent Mac app. Browser rules and extension status travel only between the extension and Intent's native helper on the same computer.

Intentions, settings, and custom background images are stored locally on the user's Mac. Removing Intent does not automatically upload or transfer this data anywhere.

Questions can be opened as a [GitHub issue](https://github.com/logx8x-ui/intent-cli/issues).
