**Intent: measure the first win, then make Cmd+G the reflex**

**My recommendation: PostHog for product analytics.** Its Swift SDK explicitly supports native macOS; it isn’t limited to websites. The free plan currently includes 1 million analytics events/month. TelemetryDeck is a good, simpler alternative built around privacy and native apps, but new accounts get 50,000 free events/month. Pick one; don’t maintain two analytics systems. Keep Sentry as a separate option for crash diagnostics.

**Collect a small, opt-in event set:** onboarding step completed, permission granted/failed, browser connected/failed, Cmd+G opened, intention started/completed/cancelled, saved intention reused, safety stop, and update installed. Attach app version, browser family and coarse duration—not emails, intention text, window titles, URLs or screenshots. Disable automatic capture and replay. Use a random installation ID and provide an off switch.

**One weekly dashboard:** first-session completion rate, median time to first session, Cmd+G-to-start conversion, seven-day return rate, and setup failures by app version. Define activation as finishing an intention, not creating an account. With a handful of testers, review individual journeys and ask where they got stuck before trusting percentages.

**Make Cmd+G a habit:** teach it by having the user actually press it during onboarding. Let them choose a cue: “When I sit down to study, I press Cmd+G.” Put their last intention first, keep repeat starts quick, and deliver the immediate reward of a calmer workspace. Offer a gentle, optional cue reminder; avoid guilt streaks and constant nudges. These are product hypotheses informed by research on repetition in consistent contexts—not a guaranteed habit formula. Test with five friends for a week: do they start sessions without you reminding them?

Sources: [PostHog macOS SDK](https://github.com/PostHog/posthog-ios/blob/main/Package.swift), [pricing](https://posthog.com/pricing), [TelemetryDeck pricing](https://telemetrydeck.com/blog/pricing-update-2026/), [habit research](https://blogs.ucl.ac.uk/bsh/2012/06/29/busting-the-21-days-habit-formation-myth/).
